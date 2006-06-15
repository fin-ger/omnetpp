package org.omnetpp.scave2.actions;

import org.eclipse.jface.viewers.IStructuredSelection;
import org.omnetpp.scave2.editors.ScaveEditor;

/**
 * ...
 */
public class UngroupAction extends AbstractScaveAction {
	public UngroupAction() {
		setText("Ungroup");
		setToolTipText("Remove group item and merge its contents");
	}

	@Override
	protected void doRun(ScaveEditor editor, IStructuredSelection selection) {
		//TODO
	}

	@Override
	protected boolean isApplicable(ScaveEditor editor, IStructuredSelection selection) {
		return true; //TODO
	}
}
